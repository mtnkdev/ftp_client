#include <stdio.h>
#include <stdlib.h>
#include <glib.h>

#include "regex.h"

//------------------------------------------- Expressions regulieres -----------------------------------------------------

gchar ** recup_match_chaine(const gchar *expr, const gchar *chaine) {
	int nb_chaines_capturees = 0;
	gchar **result = NULL;
	GMatchInfo *match_info = NULL;

	GError *err = NULL;
	GRegex *reg = g_regex_new(expr, 0, 0, &err);
	if (reg == NULL) { // si l'expression n'est pas correcte
		fprintf(stderr, "ERR : La chaine %s n'est pas une expression reguliere correcte car : %s\n", expr, (err)->message);
		return NULL;
	}

	if (g_regex_match(reg, chaine, 0, &match_info)) {
		int i;

		// on compte le nombre de captures recherchees et trouvees dans la chaine
		nb_chaines_capturees = g_regex_get_capture_count(reg);
		//fprintf(stderr, "%d chaines capturees\n",  nb_chaines_capturees);

		// on reserve de la place pour stocker les chaines trouvees
		result = g_malloc0((nb_chaines_capturees+1)*sizeof(char*));

		// on lit les valeurs trouvees
		// attention, les chaines trouvees sont de 1 a  nb_chaines_capturees
		for (i=1; i<=nb_chaines_capturees; i++) {
			gchar *word = g_match_info_fetch (match_info, i);
			result[i-1] = word;
		}
		// on ajoute NULL dans la derniere case pour signaler la fin de la liste
		result[nb_chaines_capturees] = NULL;
	} else {   
		//fprintf(stderr, "la chaine %s ne correspond pas a  l'expression %s\n", chaine, expr);
		result = NULL;
	}
  
	g_match_info_free(match_info);
	g_regex_unref(reg);

	return result;
}
